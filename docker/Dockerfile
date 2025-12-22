# syntax=docker/dockerfile:1
# Magento with Sample Data
# Build: docker buildx build --build-arg MAGENTO_VERSION=2.4.6 --build-arg PHP_VERSION=8.2 --secret id=composer_auth,src=auth.json -t ghcr.io/brtkwr/magento:2.4.6 --push .
ARG PHP_VERSION=8.2
FROM ghcr.io/brtkwr/magento-base:php${PHP_VERSION}

ARG MAGENTO_VERSION=2.4.6

WORKDIR /var/www/html

# Copy version-specific composer file
COPY composer-${MAGENTO_VERSION}.json composer.json

# Install Magento and sample data
# Requires auth.json with Magento repo credentials
RUN --mount=type=secret,id=composer_auth,target=/root/.composer/auth.json \
    --mount=type=cache,target=/root/.composer/cache \
    composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader

# Set permissions
RUN chown -R www-data:www-data /var/www/html && \
    find var generated vendor pub/static pub/media app/etc -type f -exec chmod g+w {} + 2>/dev/null || true && \
    find var generated vendor pub/static pub/media app/etc -type d -exec chmod g+ws {} + 2>/dev/null || true

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health_check.php || exit 1
