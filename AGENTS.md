# AGENTS.md

This project deploys through `zenith-compose.yml`. Before changing dependencies, build output, startup commands, ports, environment variables, or persistent storage, read `.agents/skills/create-zenith-compose/SKILL.md` and `docs/zenith-deployment.md`. Refresh the upstream skill as directed, then update the Dockerfile, image workflow, and Zenith manifest where needed. Keep the image digest in sync with the release being proposed; publishing an image alone does not deploy it on Zenith.
