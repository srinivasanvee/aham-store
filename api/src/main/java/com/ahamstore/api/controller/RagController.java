package com.ahamstore.api.controller;

import com.ahamstore.api.model.QueryRequest;
import com.ahamstore.api.model.QueryResponse;
import com.ahamstore.api.service.EmbeddingService;
import com.ahamstore.api.service.GenerationService;
import com.ahamstore.api.service.VectorSearchService;
import com.ahamstore.api.service.VectorSearchService.Chunk;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api")
public class RagController {

    private final EmbeddingService embeddingService;
    private final VectorSearchService vectorSearchService;
    private final GenerationService generationService;

    public RagController(EmbeddingService embeddingService,
                         VectorSearchService vectorSearchService,
                         GenerationService generationService) {
        this.embeddingService = embeddingService;
        this.vectorSearchService = vectorSearchService;
        this.generationService = generationService;
    }

    @PostMapping("/query")
    public ResponseEntity<QueryResponse> query(
            @AuthenticationPrincipal Jwt jwt,
            @RequestBody QueryRequest req) throws Exception {

        String userId = jwt.getSubject();
        String question = req.getQuestion();

        double[] queryEmbedding = embeddingService.embed(question);

        List<Chunk> chunks = vectorSearchService.findSimilar(userId, queryEmbedding);
        if (chunks.isEmpty()) {
            return ResponseEntity.ok(QueryResponse.builder()
                .answer("No relevant documents found. Please upload some documents first.")
                .sources(List.of())
                .build());
        }

        String answer = generationService.generate(question, chunks);

        List<String> sources = chunks.stream()
            .map(Chunk::source)
            .distinct()
            .toList();

        return ResponseEntity.ok(QueryResponse.builder()
            .answer(answer)
            .sources(sources)
            .build());
    }
}
