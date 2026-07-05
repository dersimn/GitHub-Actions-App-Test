# Dependabot/Renovate keeps this base image up to date automatically.
# It will open a PR bumping the tag when a newer Alpine release exists.
FROM alpine:3.24

RUN apk add --no-cache ca-certificates

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
