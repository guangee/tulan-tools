FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TULAN_SRC=/src/tulan-tools

ENV TULAN_TOOLS_HOME=/root/.tulan-tools
ENV PATH=/root/.tulan-tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY . /src/tulan-tools
RUN chmod +x /src/tulan-tools/docker/common/bootstrap.sh \
    && bash /src/tulan-tools/docker/common/bootstrap.sh

CMD ["bash", "-c", "brew time status && brew mirrors status && echo 'verify ok'"]
