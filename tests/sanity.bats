#!/usr/bin/env bats
# tests/sanity.bats — Smoke test da infraestrutura Bats
# Verifica que helpers e bats-assert funcionam corretamente.

load 'helpers/setup'
load 'lib/bats-support/load'
load 'lib/bats-assert/load'

@test "sanity: assert_equal funciona" {
  assert_equal "1" "1"
}
