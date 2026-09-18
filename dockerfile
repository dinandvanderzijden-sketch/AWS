FROM nginx:alpine
RUN echo "<h1>Infrastructuur Succesvol Uitgerold via GitHub Actions!</h1>" > /usr/share/nginx/html/index.html
EXPOSE 80