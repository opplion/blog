FROM node:20-alpine AS builder
WORKDIR /blog

COPY . .

RUN npm install -g hexo-cli && npm install && hexo clean && hexo generate

FROM nginx:alpine

COPY --from=builder /blog/public /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]