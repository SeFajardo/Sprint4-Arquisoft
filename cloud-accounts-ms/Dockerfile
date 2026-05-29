FROM python:3.12-alpine
WORKDIR /app
COPY . /app
ENV DB_HOST=10.0.0.10
ENV DB_PORT=5432
ENV DB_NAME=cloud_accounts
ENV DB_USER=bite_admin
ENV DB_PASS=bite_secure_pass
RUN apk update && apk add postgresql-dev gcc python3-dev musl-dev
RUN pip install --no-cache-dir -r requirements.txt
ENTRYPOINT ["sh", "init.sh"]
