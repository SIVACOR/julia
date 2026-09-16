# SIVACOR's Julia analysis image: the official image, plus the two things a
# SIVACOR run needs that it does not have.
#
# See development_notes/10_julia_support_plan.md for the reasoning; the decision
# numbers below are that file's.
ARG JULIA_TAG=1.11.9-bookworm
FROM julia:${JULIA_TAG}

# 10-D9. NOT what makes a SIVACOR run non-root: the worker forces
# `--user <its own uid>:<its own gid>`, a pair that exists in no image's
# /etc/passwd. This user is for anyone running the image directly, and for
# owning what the build writes -- which is why everything below is made
# world-readable rather than owned by it.
RUN useradd --create-home --shell /bin/bash --uid 1000 julia

# 10-D8: the General registry, and nothing else.
#
# No packages: correctness never depends on a cache, because the resolve phase
# downloads what the researcher declared. A package cache would buy runtime at
# the price of image size, build time, and a curation list we have no evidence
# for.
#
# No populated default environment: that would let `using` succeed against
# packages the researcher never declared, producing a run that works here and
# nowhere else.
#
# The registry earns its place on its own -- without it every single resolve
# clones General over the network before it can begin.
ENV JULIA_DEPOT_PATH=/opt/julia-depot
RUN julia -e 'using Pkg; Pkg.Registry.add("General")' \
 && chmod -R a+rX /opt/julia-depot

# 10-D7. Writes land in the workspace, reads fall through to the baked depot.
# HOME is set to /workspace by the worker (girder-sivacor lib.py:1574), and
# /workspace/.julia is a sibling of project/ -- so downloaded packages never
# enter the TRO composition.
ENV JULIA_DEPOT_PATH=/workspace/.julia:/opt/julia-depot

USER julia
