FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev curl \
 && rm -rf /var/lib/apt/lists/*

# Mirror the repository layout so AppSignal backtrace paths (relative to
# APPSIGNAL_APP_PATH) match files on GitHub: services/orders-web/app.rb.
ENV APPSIGNAL_APP_PATH=/app
WORKDIR /app/services/orders-web
COPY Gemfile ./
RUN bundle install --jobs 4

COPY . .
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:3000", "-t", "5:5", "config.ru"]
