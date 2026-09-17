# syntax=docker/dockerfile:1
FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html pgp.txt 88x31.gif 88x31_static.gif _headers /usr/share/nginx/html/
COPY files/ /usr/share/nginx/html/files/
COPY .well-known/ /usr/share/nginx/html/.well-known/

EXPOSE 80
