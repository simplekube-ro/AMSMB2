test:
	swift test

integrationtest:
	./scripts/test-integration.sh

# Seam leg: runs the Docker Samba integration suite through the NIO TCP transport
# (TCPTransportApple + bridge + no-fd servicing loop). Apple-only; requires Docker + a live
# Samba server. See .github/workflows/integration.yml for the CI leg.
seamintegrationtest:
	SMB_TRANSPORT=seam ./scripts/test-integration.sh

# Mount the checkout read-only at a quoted absolute path (a bare `.` is parsed by Docker as
# an invalid named volume, not a bind mount) and build in a container-local scratch path so
# no root/container-owned build products land in the checkout.
linuxtest:
	docker build -f Dockerfile -t linuxtest .
	docker run --rm -v "$(CURDIR):/home/nonroot/src/app:ro" linuxtest --scratch-path /tmp/amsmb2-build

cleanlinuxtest:
	docker build -f Dockerfile -t linuxtest .
	docker run --rm linuxtest --scratch-path /tmp/amsmb2-build
