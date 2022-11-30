FROM ingy/bpan-plugin-publish-gha-base:0.1.0

COPY bin/bpan-publish-gha /bin/bpan-publish-gha
COPY .bpan /.bpan

ENTRYPOINT ["/bin/bpan-publish-gha"]
