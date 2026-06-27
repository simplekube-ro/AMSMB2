test:
	swift test

integrationtest:
	./scripts/test-integration.sh

# Seam leg: runs the Docker Samba integration suite through the NIO TCP transport
# (TCPTransportApple + bridge + no-fd servicing loop). Apple-only; requires Docker + a live
# Samba server. See .github/workflows/integration.yml for the CI leg.
seamintegrationtest:
	SMB_TRANSPORT=seam ./scripts/test-integration.sh

linuxtest:
	docker build -f Dockerfile -t linuxtest .
	docker run --rm -v .:/home/nonroot/src/app linuxtest

cleanlinuxtest:
	docker build -f Dockerfile -t linuxtest .
	docker run --rm linuxtest
