package com.ahamstore.api.service;

import com.google.cloud.firestore.CollectionReference;
import com.google.cloud.firestore.Firestore;
import com.google.cloud.firestore.FirestoreOptions;
import com.google.cloud.firestore.QueryDocumentSnapshot;
import com.google.cloud.firestore.VectorQuery;
import com.google.cloud.firestore.VectorQuerySnapshot;
import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;

@Service
public class VectorSearchService {

    @Value("${gcp.top-k-results}")
    private int topK;

    private Firestore firestore;

    @PostConstruct
    public void init() {
        firestore = FirestoreOptions.getDefaultInstance().getService();
    }

    public record Chunk(String text, String source) {}

    public List<Chunk> findSimilar(String userId, double[] queryEmbedding)
            throws ExecutionException, InterruptedException {

        CollectionReference vectorsCol = firestore
            .collection("users")
            .document(userId)
            .collection("vectors");

        // findNearest accepts double[] directly — no FieldValue.vector() wrapper needed
        VectorQuery vectorQuery = vectorsCol.findNearest(
            "embedding",
            queryEmbedding,
            topK,
            VectorQuery.DistanceMeasure.COSINE
        );

        VectorQuerySnapshot snapshot = vectorQuery.get().get();

        List<Chunk> results = new ArrayList<>();
        for (QueryDocumentSnapshot doc : snapshot.getDocuments()) {
            results.add(new Chunk(
                doc.getString("text"),
                doc.getString("source")
            ));
        }
        return results;
    }
}
