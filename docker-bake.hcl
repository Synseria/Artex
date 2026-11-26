# Fork image build (used by .github/workflows/fork-image.yml).
#
#   docker buildx bake nonroot --set nonroot.tags=artex:nonroot --load
#   docker buildx bake base                 # upstream image, unchanged
#
# "nonroot" reuses the "base" target as its build context: a single build, no
# intermediate image to push.

variable "ARTEX_VERSION" {
  default = "dev"
}

group "default" {
  targets = ["nonroot"]
}

target "base" {
  context    = "."
  dockerfile = "Dockerfile"
  args = {
    ARTEX_VERSION = ARTEX_VERSION
  }
}

# Overridden in CI by docker/metadata-action (tags, OCI labels).
target "docker-metadata-action" {}

target "nonroot" {
  inherits   = ["docker-metadata-action"]
  context    = "."
  dockerfile = "Dockerfile.nonroot"
  contexts = {
    artex-base = "target:base"
  }
}
