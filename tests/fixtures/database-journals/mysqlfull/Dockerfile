FROM sb-validation-mysql:local
COPY mysql-full.repo /etc/yum.repos.d/mysql-full.repo
RUN microdnf remove -y mysql-community-server-minimal && microdnf install -y mysql-community-client && microdnf clean all
ENTRYPOINT ["sleep"]
CMD ["infinity"]
