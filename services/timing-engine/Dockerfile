# timing-engine container image (Node.js 22, Express, New Relic Node.js agent).
FROM node:22-slim
WORKDIR /app

# Install dependencies; "newrelic" in package.json is the Node.js APM agent.
COPY package.json .
RUN npm install --omit=dev
COPY server.js .

# NEW_RELIC_NO_CONFIG_FILE=true: read every agent setting from environment
# variables (set in k8s/apps.yaml) instead of a newrelic.js file.
ENV NEW_RELIC_NO_CONFIG_FILE=true

# "-r newrelic" loads the agent before the app, so it can instrument Express,
# pg and redis as they are required.
EXPOSE 3000
CMD ["node", "-r", "newrelic", "server.js"]
