package com.ahamstore.api.controller;

import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api")
public class UserController {

    @GetMapping("/me")
    public Map<String, String> me(@AuthenticationPrincipal Jwt jwt) {
        return Map.of(
            "sub",     jwt.getSubject(),
            "email",   jwt.getClaimAsString("email"),
            "name",    jwt.getClaimAsString("name"),
            "picture", jwt.getClaimAsString("picture")
        );
    }
}
