FROM erlang:27-alpine

WORKDIR /app

# Copy rebar config and fetch deps
COPY rebar.config rebar.lock* ./
RUN rebar3 compile || true

# Copy source and build release
COPY . .
RUN rebar3 as prod release

EXPOSE 8080

CMD ["_build/prod/rel/ws_example/bin/ws_example", "foreground"]
