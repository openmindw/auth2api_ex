ARG ELIXIR_VERSION="1.19.5"
ARG OTP_VERSION="28"
ARG BUILDER_IMAGE="docker.io/library/elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim"
ARG RUNNER_IMAGE="debian:bookworm-slim"

# Build stage
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Build dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

# Build app
COPY lib lib
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM ${RUNNER_IMAGE} AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

WORKDIR /app

RUN chown nobody /app

# Copy release from builder
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/auth2api_ex ./

USER nobody

EXPOSE 8318

VOLUME ["/data", "/config"]

ENV AUTH2API_CONFIG=/config/config.yaml

CMD ["/app/bin/auth2api_ex", "start"]
