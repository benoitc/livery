# Livery Compliance Testing Makefile
#
# Targets:
#   make compliance       - Run all compliance tests
#   make h2spec-test      - Run h2spec HTTP/2 tests
#   make autobahn-test    - Run Autobahn WebSocket tests
#   make curl-test        - Run curl HTTP/1.1 tests
#   make download-h2spec  - Download h2spec binary
#   make test-certs       - Generate test certificates

REBAR ?= rebar3
UNAME := $(shell uname -s)
ARCH := $(shell uname -m)
H2SPEC_VERSION := 2.6.0
TOOLS_DIR := priv/tools
CERTS_DIR := priv/test_certs

# h2spec binary URL based on platform
# Note: h2spec doesn't have arm64 builds, use amd64 via Rosetta on macOS arm64
ifeq ($(UNAME),Darwin)
    H2SPEC_PLATFORM := darwin_amd64
else ifeq ($(UNAME),Linux)
    H2SPEC_PLATFORM := linux_amd64
endif

H2SPEC_URL := https://github.com/summerwind/h2spec/releases/download/v$(H2SPEC_VERSION)/h2spec_$(H2SPEC_PLATFORM).tar.gz
H2SPEC_BIN := $(TOOLS_DIR)/h2spec

.PHONY: all compile test eunit ct compliance h2spec-test autobahn-test curl-test \
        download-h2spec test-certs clean-tools clean

all: compile

compile:
	$(REBAR) compile

test: eunit ct

eunit:
	$(REBAR) eunit

ct:
	$(REBAR) ct

# Compliance testing targets
compliance: test-certs download-h2spec
	$(REBAR) ct --suite=test/compliance/livery_compliance_SUITE

h2spec-test: test-certs download-h2spec
	$(REBAR) ct --suite=test/compliance/livery_compliance_SUITE --group=h2spec_tests

autobahn-test: test-certs
	$(REBAR) ct --suite=test/compliance/livery_compliance_SUITE --group=autobahn_tests

curl-test: test-certs
	$(REBAR) ct --suite=test/compliance/livery_compliance_SUITE --group=curl_tests

# Download h2spec binary
$(TOOLS_DIR):
	mkdir -p $(TOOLS_DIR)

download-h2spec: $(TOOLS_DIR)
	@if [ ! -f $(H2SPEC_BIN) ]; then \
		echo "Downloading h2spec $(H2SPEC_VERSION) for $(H2SPEC_PLATFORM)..."; \
		curl -sL $(H2SPEC_URL) | tar -xzf - -C $(TOOLS_DIR); \
		chmod +x $(H2SPEC_BIN); \
		echo "h2spec downloaded to $(H2SPEC_BIN)"; \
	else \
		echo "h2spec already exists at $(H2SPEC_BIN)"; \
	fi

# Generate test certificates
$(CERTS_DIR):
	mkdir -p $(CERTS_DIR)

test-certs: $(CERTS_DIR)
	@if [ ! -f $(CERTS_DIR)/server.crt ]; then \
		echo "Generating test certificates..."; \
		openssl req -x509 -newkey rsa:2048 -nodes \
			-keyout $(CERTS_DIR)/server.key \
			-out $(CERTS_DIR)/server.crt \
			-days 365 \
			-subj "/CN=localhost/O=Livery Test/C=US" \
			-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"; \
		echo "Test certificates generated in $(CERTS_DIR)"; \
	else \
		echo "Test certificates already exist in $(CERTS_DIR)"; \
	fi

# Clean targets
clean-tools:
	rm -rf $(TOOLS_DIR)
	rm -rf $(CERTS_DIR)

clean: clean-tools
	$(REBAR) clean

# Help
help:
	@echo "Livery Compliance Testing"
	@echo ""
	@echo "Targets:"
	@echo "  make compile        - Compile the project"
	@echo "  make test           - Run unit and CT tests"
	@echo "  make compliance     - Run all compliance tests"
	@echo "  make h2spec-test    - Run h2spec HTTP/2 tests (156+ tests)"
	@echo "  make autobahn-test  - Run Autobahn WebSocket tests (requires Docker)"
	@echo "  make curl-test      - Run curl HTTP/1.1 tests"
	@echo "  make download-h2spec- Download h2spec binary"
	@echo "  make test-certs     - Generate self-signed test certificates"
	@echo "  make clean          - Clean build and tools"
	@echo ""
	@echo "Requirements:"
	@echo "  - Erlang/OTP 27+"
	@echo "  - Docker (for Autobahn tests)"
	@echo "  - curl (for HTTP/1.1 tests)"
	@echo "  - openssl (for certificate generation)"
