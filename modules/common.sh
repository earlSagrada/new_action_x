#!/usr/bin/env bash

log() {
  echo -e "\033[32m[*]\033[0m $*"
}

err() {
  echo -e "\033[31m[!]\033[0m $*" >&2
}

warn() {
  echo -e "\033[33m[!]\033[0m $*"
}
