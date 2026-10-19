package com.paulsnow.finance.server.common;

import java.io.IOException;
import java.io.InputStream;
import java.security.interfaces.RSAPublicKey;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.core.io.Resource;
import org.springframework.security.converter.RsaKeyConverters;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

/**
 * Local end-to-end tests only ({@code tool/e2e/run.sh}): verifies access
 * tokens with the static test public key named by
 * {@code spring.security.oauth2.resourceserver.jwt.public-key-location}
 * and checks their {@code iss} against {@code issuer-uri} without ever
 * contacting it. Spring Boot prefers the issuer's discovery when both
 * properties are set, so this profile builds the key-based decoder itself.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
@Profile("e2e")
class EndToEndJwtConfiguration {

    @Bean
    JwtDecoder endToEndJwtDecoder(
            @Value("${spring.security.oauth2.resourceserver.jwt.public-key-location}") Resource publicKey,
            @Value("${spring.security.oauth2.resourceserver.jwt.issuer-uri}") String issuer) throws IOException {
        RSAPublicKey key;
        try (InputStream in = publicKey.getInputStream()) {
            key = RsaKeyConverters.x509().convert(in);
        }
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey(key).build();
        decoder.setJwtValidator(JwtValidators.createDefaultWithIssuer(issuer));
        return decoder;
    }
}
