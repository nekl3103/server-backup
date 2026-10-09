FROM sb-validation-pg:local
RUN apt-get update -qq && apt-get install -y -qq openssh-server openssh-client restic && rm -rf /var/lib/apt/lists/*
ENTRYPOINT []
CMD ["sleep", "infinity"]
