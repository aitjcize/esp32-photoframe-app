.PHONY: format format-check install-hooks

# Format Dart sources.
format:
	dart format lib test

# Verify formatting without writing (used by the pre-commit hook / CI).
format-check:
	dart format --output=none --set-exit-if-changed lib test

# Enable the repo's git hooks (pre-commit runs `make format-check`).
install-hooks:
	@git config core.hooksPath .githooks
	@echo "Git hooks enabled (core.hooksPath = .githooks)."
	@echo "Commits now run 'make format-check' first."
