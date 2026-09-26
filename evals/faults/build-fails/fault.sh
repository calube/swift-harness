#!/usr/bin/env bash
set -euo pipefail
printf '\nlet brokenOnPurpose: Int = "not an int"\n' >> Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift
