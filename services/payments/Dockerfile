FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev curl \
 && rm -rf /var/lib/apt/lists/*

# Mirror the repository layout so AppSignal backtrace paths (relative to
# APPSIGNAL_APP_PATH) match files on GitHub: services/payments/app.rb.
ENV APPSIGNAL_APP_PATH=/app
WORKDIR /app/services/payments
COPY Gemfile ./
RUN bundle install --jobs 4

COPY . .
EXPOSE 4000
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:4000", "-t", "5:5", "config.ru"]
