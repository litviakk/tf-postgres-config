# Integration test target: PostgreSQL 17 + sshd on Debian bookworm.
# The postgres user is the SSH user (passwordless sudo, key auth only).
FROM postgres:18-trixie

ENV POSTGRES_PASSWORD=testpassword \
    POSTGRES_HOST_AUTH_METHOD=trust

RUN apt-get update -qq && apt-get install -y -qq \
    openssh-server \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create required directories.
RUN mkdir -p /run/sshd /root/.ssh

# Allow the postgres OS user to SSH in and use passwordless sudo.
RUN echo 'postgres ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/postgres \
    && chmod 440 /etc/sudoers.d/postgres

# SSH config: key auth only, no root login via password.
RUN sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
    /etc/ssh/sshd_config

# Authorised keys for the postgres user are injected at runtime via
# docker exec (see integration test setup).
RUN mkdir -p /var/lib/postgresql/.ssh \
    && chown postgres:postgres /var/lib/postgresql/.ssh \
    && chmod 700 /var/lib/postgresql/.ssh

# Create conf.d and configure include_dir.
# The entrypoint initialises PGDATA (/var/lib/postgresql/data) on first run;
# we patch postgresql.conf after initdb via a docker-entrypoint-initdb.d script.
COPY initdb-conf-d.sh /docker-entrypoint-initdb.d/01-conf-d.sh
RUN chmod +x /docker-entrypoint-initdb.d/01-conf-d.sh

# Expose SSH and PostgreSQL ports.
EXPOSE 22 5432

# Override the default entrypoint with tini so sshd and postgres can coexist.
# tini is bundled in the official postgres image.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint-wrapper.sh"]

COPY docker-entrypoint-wrapper.sh /usr/local/bin/docker-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-wrapper.sh
