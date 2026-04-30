FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
    software-properties-common \
    ffmpeg \
    pulseaudio \
    python3-pip \
    xvfb \
    firefox \
    curl \
    ca-certificates \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install geckodriver
RUN GECKO_VERSION=$(curl -sL https://api.github.com/repos/mozilla/geckodriver/releases/latest | grep tag_name | cut -d'"' -f4) && \
    wget -q "https://github.com/mozilla/geckodriver/releases/download/${GECKO_VERSION}/geckodriver-${GECKO_VERSION}-linux64.tar.gz" -O /tmp/geckodriver.tar.gz && \
    tar -xzf /tmp/geckodriver.tar.gz -C /usr/local/bin/ && \
    rm /tmp/geckodriver.tar.gz && \
    chmod +x /usr/local/bin/geckodriver

# Install nextcloud-talk-recording from git
RUN pip3 install --no-cache-dir --upgrade requests && \
    pip3 install --no-cache-dir "git+https://github.com/nextcloud/nextcloud-talk-recording.git@main"

# Create recording user and directories
RUN useradd --create-home recording && \
    mkdir -p /etc/nextcloud-talk-recording /tmp/recordings && \
    chown recording:recording /tmp/recordings

# Copy configuration file
COPY server.conf /etc/nextcloud-talk-recording/server.conf

# Switch user and start the recording server
WORKDIR "/home/recording/"
USER "recording"
CMD ["python3", "-m", "nextcloud.talk.recording", "--config", "/etc/nextcloud-talk-recording/server.conf"]
