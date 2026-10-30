# Signing for `make release`: an untracked local.mk with
#   export SIGN_ID = Developer ID Application: Name (TEAM)
#   export NOTARY_PROFILE = <notarytool keychain profile>
-include local.mk
dev:
	scripts/bundle.sh dev
dev-home:
	scripts/dev-home.sh
beta:
	scripts/bundle.sh beta
publish-beta:
	scripts/publish-beta.sh
release:
	scripts/bundle.sh
	scripts/install.sh
install:
	scripts/install.sh
publish:
	scripts/publish.sh
.PHONY: dev dev-home beta publish-beta release install publish
