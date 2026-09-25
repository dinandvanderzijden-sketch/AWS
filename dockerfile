FROM nginx:alpine
RUN echo "<h1>Infrastructuur Succesvol Uitgerold via GitHub Actions!</h1>" > /usr/share/nginx/html/index.html && \
    echo "OK" > /usr/share/nginx/html/healthz
COPY default.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
