// timing-engine: calculates the signal timing plan for each intersection.
//
// WHERE IT RUNS
//   Kubernetes (k3s), namespace "corridor", internal service on port 3000.
//
// WHAT IT DOES
//   GET /plans/:intersectionId returns the timing plan the controller at that
//   intersection should run. The key safety value is the YELLOW (change) interval,
//   calculated with the standard kinematic formula traffic engineers use:
//
//       yellow = perception_reaction_time + approach_speed / (2 x deceleration)
//
//   with perception-reaction time 1.0 s, deceleration 10 ft/s^2, level grade,
//   and approach speed in FEET PER SECOND (mph x 1.467).
//   Example: 45 mph = 66 ft/s, so yellow = 1.0 + 66 / 20 = 4.3 seconds.
//
//   Each intersection's speed limit is read from PostgreSQL and cached in Redis
//   for 60 seconds, so traces show both datastores.
//
// THE DEMO INCIDENT (PLAN_VERSION=2026.2)
//   Release 2026.2 "adds metric unit support". It converts the approach speed to
//   METERS per second but still feeds it into the formula as if it were feet per
//   second. 45 mph becomes 20.1 instead of 66, so yellow drops from 4.3 s to 2.0 s.
//   Every intersection falls below the 3-second minimum, yet every request still
//   succeeds with HTTP 200. Error rate stays at 0%. Nothing crashes.
//
// HOW IT IS MONITORED
//   New Relic Node.js APM agent, loaded before any other code with
//   `node -r newrelic` (see Dockerfile). It instruments Express, pg and redis
//   automatically. Custom attributes below add the plan details to every trace,
//   and pino log lines are forwarded with trace IDs (logs in context).
'use strict';

const newrelic = require('newrelic');
const express = require('express');
const { Pool } = require('pg');
const { createClient } = require('redis');
const pino = require('pino');

const log = pino({ base: { service: 'timing-engine' } });

// Read on every request so a `kubectl set env` rollout changes behavior cleanly.
const planVersion = () => process.env.PLAN_VERSION || '2026.1';

// Timing constants (seconds, feet, feet per second squared).
const PERCEPTION_REACTION_S = 1.0;
const DECELERATION_FTPS2 = 10.0;
const ALL_RED_S = 1.5;
const CYCLE_S = 120;

const pg = new Pool({
  host: process.env.PG_HOST,
  port: Number(process.env.PG_PORT || 5432),
  database: process.env.PG_DB || 'corridor',
  user: process.env.PG_USER || 'corridor',
  password: process.env.PG_PASSWORD,
  max: 5,
});

const redis = createClient({
  socket: { host: process.env.REDIS_HOST, port: Number(process.env.REDIS_PORT || 6379) },
  password: process.env.REDIS_PASSWORD,
});
redis.on('error', (err) => log.error({ err: err.message }, 'redis error'));

// Speed limit for an intersection: Redis first, PostgreSQL on a cache miss.
async function intersectionInfo(id) {
  const key = `intersection:${id}`;
  const cached = await redis.get(key);
  if (cached) return { ...JSON.parse(cached), cache: 'hit' };
  const { rows } = await pg.query('SELECT name, speed_mph FROM intersections WHERE id = $1', [id]);
  if (!rows.length) return null;
  const info = { name: rows[0].name, speedMph: Number(rows[0].speed_mph) };
  await redis.set(key, JSON.stringify(info), { EX: 60 });
  return { ...info, cache: 'miss' };
}

// The yellow interval calculation, including the 2026.2 defect.
function yellowSeconds(speedMph, version) {
  let approachSpeed;
  if (version === '2026.2') {
    // DEFECT: meters per second, but the formula below expects feet per second.
    approachSpeed = speedMph * 0.447;
  } else {
    approachSpeed = speedMph * 1.467; // correct: feet per second
  }
  const y = PERCEPTION_REACTION_S + approachSpeed / (2 * DECELERATION_FTPS2);
  return Math.round(y * 10) / 10;
}

const app = express();

app.get('/plans/:id', async (req, res) => {
  const id = Number(req.params.id);
  const version = planVersion();
  try {
    const info = await intersectionInfo(id);
    if (!info) return res.status(404).json({ error: `unknown intersection ${id}` });

    const yellow = yellowSeconds(info.speedMph, version);
    // Simple fixed split: main street gets 60% of the green time.
    const greenTotal = CYCLE_S - 2 * (yellow + ALL_RED_S);
    const plan = {
      intersection_id: id,
      intersection_name: info.name,
      plan_version: version,
      speed_mph: info.speedMph,
      cycle_s: CYCLE_S,
      yellow_s: yellow,
      all_red_s: ALL_RED_S,
      green_main_s: Math.round(greenTotal * 0.6),
      green_side_s: Math.round(greenTotal * 0.4),
    };

    // Attach plan details to this transaction. In a trace, clicking the
    // timing-engine span shows these values, which is how the developer finds
    // the cause in the demo.
    newrelic.addCustomAttributes({
      intersectionId: id,
      planVersion: version,
      yellowSeconds: yellow,
      speedMph: info.speedMph,
      speedCache: info.cache,
    });
    log.info({ intersectionId: id, planVersion: version, yellowSeconds: yellow, cache: info.cache },
      'timing plan served');
    return res.json(plan);
  } catch (err) {
    newrelic.noticeError(err);
    log.error({ err: err.message, intersectionId: id }, 'timing plan failed');
    return res.status(500).json({ error: 'timing plan unavailable' });
  }
});

app.get('/healthz', (_req, res) => {
  newrelic.getTransaction().ignore(); // keep health checks out of APM data
  res.json({ status: 'ok' });
});

(async () => {
  await redis.connect();
  app.listen(3000, () => log.info({ planVersion: planVersion() }, 'timing-engine listening on 3000'));
})();
