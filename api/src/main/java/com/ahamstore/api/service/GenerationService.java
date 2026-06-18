package com.ahamstore.api.service;

import com.google.cloud.vertexai.VertexAI;
import com.google.cloud.vertexai.api.GenerateContentResponse;
import com.google.cloud.vertexai.generativeai.GenerativeModel;
import com.google.cloud.vertexai.generativeai.ResponseHandler;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.List;
import java.util.stream.Collectors;

@Service
public class GenerationService {

    @Value("${gcp.project-id}")
    private String projectId;

    @Value("${gcp.location}")
    private String location;

    @Value("${gcp.gemini-model}")
    private String geminiModel;

    private VertexAI vertexAI;
    private GenerativeModel model;

    @PostConstruct
    public void init() throws IOException {
        vertexAI = new VertexAI(projectId, location);
        model = new GenerativeModel(geminiModel, vertexAI);
    }

    @PreDestroy
    public void destroy() throws IOException {
        if (vertexAI != null) {
            vertexAI.close();
        }
    }

    public String generate(String question, List<VectorSearchService.Chunk> chunks) throws IOException {
        String context = chunks.stream()
            .map(VectorSearchService.Chunk::text)
            .collect(Collectors.joining("\n\n---\n\n"));

        String prompt = """
            You are a helpful assistant. Answer the question using only the provided context.
            If the context does not contain enough information to answer, say so clearly.

            Context:
            %s

            Question: %s

            Answer:
            """.formatted(context, question);

        GenerateContentResponse response = model.generateContent(prompt);
        return ResponseHandler.getText(response);
    }
}
