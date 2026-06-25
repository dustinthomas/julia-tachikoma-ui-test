# Dockerfile
# Containerized execution for Node.js / TypeScript parts of this project.
# (Follows policy: run Node in Docker.)
#
# Build: docker build -t julia-tachikoma-ui-test .
# Run test: docker run --rm julia-tachikoma-ui-test npm test
# With live source: docker run --rm -v $(pwd):/app -v /app/node_modules julia-tachikoma-ui-test npm test

FROM node:20-slim

WORKDIR /app

COPY package.json ./
RUN npm install

COPY . .

CMD ["npm", "run", "dev"]
