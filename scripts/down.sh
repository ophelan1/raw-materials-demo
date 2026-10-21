#!/usr/bin/env bash
# Deletes the demo cluster. Run `colima stop` afterwards to free the VM's memory.
set -euo pipefail
kind delete cluster --name ijzerhaven
