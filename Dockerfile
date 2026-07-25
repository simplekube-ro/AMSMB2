FROM swift:6.1

# Add nonroot user
RUN groupadd -r nonroot && useradd -r -g nonroot nonroot

# Create app directory as root
RUN mkdir -p /home/nonroot && chown -R nonroot:nonroot /home/nonroot
RUN mkdir -p /home/nonroot/src/app && chown -R nonroot:nonroot /home/nonroot/src/app
USER nonroot

# Change working dir to /usr/src/app
WORKDIR /home/nonroot/src/app
VOLUME /home/nonroot/src/app

COPY --chown=nonroot:nonroot AMSMB2 ./AMSMB2
COPY --chown=nonroot:nonroot AMSMB2Tests ./AMSMB2Tests
COPY --chown=nonroot:nonroot Dependencies ./Dependencies
COPY --chown=nonroot:nonroot Package.swift Package.resolved ./

ENTRYPOINT ["swift", "test"]
