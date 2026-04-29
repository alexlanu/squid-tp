# --- Этап 1: Сборка Squid из исходного кода ---
FROM alpine:3.23 AS builder

# Устанавливаем зависимости для компиляции (добавлен bash, perl, pkgconfig)
RUN apk add --no-cache \
    build-base \
    openssl-dev \
    openssl-libs-static \
    linux-headers \
    gcc \
    make \
    tar \
    wget \
    bash \
    pkgconfig \
    perl

# Аргументы для версии Squid
ARG SQUID_VERSION=6.14
#ARG SQUID_URL=https://www.squid-cache.org/Versions/v6/squid-${SQUID_VERSION}.tar.gz
ARG SQUID_URL=https://github.com/squid-cache/squid/releases/download/SQUID_6_14/squid-6.14.tar.gz

# Скачиваем и распаковываем исходный код Squid из официального архива
WORKDIR /tmp
RUN wget -O squid.tar.gz ${SQUID_URL} \
 && tar -xzf squid.tar.gz \
 && cd squid-${SQUID_VERSION} \
 && ls -la   # для отладки: убедимся, что configure существует

# Конфигурируем, компилируем и устанавливаем Squid
WORKDIR /tmp/squid-${SQUID_VERSION}
# Добавляем --disable-arch-native для совместимости, но оставляем возможность кастомизации
RUN ./configure \
    --prefix=/usr/local/squid \
    --enable-ssl \
    --enable-ssl-crtd \
    --with-openssl \
    --disable-setuid \
    --datadir=/usr/share/squid \
    --sysconfdir=/etc/squid \
    --with-swapdir=/var/spool/squid \
    --with-logdir=/var/log/squid \
    --with-pidfile=/run/squid.pid \
    --with-filedescriptors=65536 \
    --with-large-files \
    --with-default-user=squid \
    --disable-strict-error-checking \
    "CFLAGS=-g -O2 -Werror=implicit-function-declaration -ffile-prefix-map=/build/reproducible-path/squid-${SQUID_VERSION}=. -fstack-protector-strong -fstack-clash-protection -Wformat -Werror=format-security -fcf-protection -Wno-error=deprecated-declarations" \
    "LDFLAGS=-Wl,-z,relro -Wl,-z,now" \
    "CPPFLAGS=-Wdate-time -D_FORTIFY_SOURCE=2" \
    "CXXFLAGS=-g -O2 -ffile-prefix-map=/build/reproducible-path/squid-${SQUID_VERSION}=. -fstack-protector-strong -fstack-clash-protection -Wformat -Werror=format-security -fcf-protection -Wno-error=deprecated-declarations"
RUN make -j$(nproc)
RUN make install

# --- Этап 2: Финальный образ с результатом сборки ---
FROM alpine:3.23
ARG SQUID_VERSION=6.14

# Копируем из образа-сборщика только установленный Squid
COPY --from=builder /usr/local/squid /usr/local/squid
COPY --from=builder /tmp/squid-${SQUID_VERSION}/icons /usr/share/squid/icons
COPY --from=builder /tmp/squid-${SQUID_VERSION}/errors /usr/share/squid/errors

# Устанавливаем runtime-зависимости: openssl и базовые библиотеки
RUN apk add --no-cache \
    openssl \
    libgcc \
    libstdc++

# Создаём все необходимые директории
RUN mkdir -p /var/cache/squid /var/log/squid /usr/local/squid/var/logs /usr/local/bin /var/spool/squid /var/lib/squid 
# /usr/share/squid/icons /usr/share/squid/errors

# Создаём симлинк в существующую директорию /usr/local/bin
RUN ln -sf /usr/local/squid/sbin/squid /usr/local/bin/squid

# Проверка, что бинарник скопировался
RUN test -f /usr/local/squid/sbin/squid || (echo "ERROR: squid binary not found" && ls -la /usr/local/squid && exit 1)

# Настройка прав доступа для пользователя squid
RUN addgroup -S squid && adduser -S squid -G squid && \
    chown -R squid:squid /usr/local/squid /var/cache/squid /var/log/squid /run /var/spool/squid /var/lib/squid /usr/share/squid/icons

# Переключаемся на непривилегированного пользователя
USER squid

# Инициализация хранилища сертификатов
RUN /usr/local/squid/libexec/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB

# Открываем стандартный порт Squid
#EXPOSE 3128

# Запускаем Squid в режиме foreground
#CMD ["/usr/local/squid/sbin/squid", "-NYCd", "1"]
CMD ["sh", "-c", "rm -f /run/squid.pid && exec /usr/local/squid/sbin/squid -NYCd 1"]
