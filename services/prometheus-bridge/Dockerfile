FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

ENV APPSIGNAL_APP_PATH=/app
WORKDIR /app/services/prometheus-bridge
COPY Gemfile ./
RUN bundle install --jobs 4
COPY . .
CMD ["bundle", "exec", "ruby", "bridge.rb"]
