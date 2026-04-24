# ----- Stage 1: Build -----
FROM node:22-alpine AS builder

WORKDIR /app

# Install deps first for layer caching
COPY ./frontend/package*.json ./
RUN npm ci --no-audit --no-fund || npm install

# Copy the whole frontend source.
# NOTE: `.env.local` is copied along with it, so all NEXT_PUBLIC_* vars
# are baked into the production bundle at build time. Update
# frontend/.env.local before rebuilding the frontend image.
COPY ./frontend .

RUN npm run build

# ----- Stage 2: Run -----
FROM node:22-alpine

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

COPY ./frontend/package*.json ./

COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
COPY --from=builder /app/node_modules ./node_modules

EXPOSE 3000
CMD ["npm", "run", "start"]
