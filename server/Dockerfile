# ArchiSteamFarm, configured from environment variables, for idling Steam games
# 24/7 on a headless host such as Railway. Setup: README.md in this folder.
FROM justarchi/archisteamfarm:stable

COPY entrypoint.sh /usr/local/bin/steamidler-entrypoint
RUN chmod 755 /usr/local/bin/steamidler-entrypoint

ENTRYPOINT ["/usr/local/bin/steamidler-entrypoint"]
