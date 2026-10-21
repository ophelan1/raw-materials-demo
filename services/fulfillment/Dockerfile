FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev \
 && rm -rf /var/lib/apt/lists/*

ENV APPSIGNAL_APP_PATH=/app RAILS_ENV=production
WORKDIR /app/services/fulfillment
COPY Gemfile ./
RUN bundle install --jobs 4
COPY . .
CMD ["sh", "-c", "bin/setup_db && exec bin/jobs"]
