package com.ahamstore.api.service;

import com.google.cloud.aiplatform.v1.EndpointName;
import com.google.cloud.aiplatform.v1.PredictRequest;
import com.google.cloud.aiplatform.v1.PredictResponse;
import com.google.cloud.aiplatform.v1.PredictionServiceClient;
import com.google.cloud.aiplatform.v1.PredictionServiceSettings;
import com.google.protobuf.ListValue;
import com.google.protobuf.Struct;
import com.google.protobuf.Value;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.IOException;

@Service
public class EmbeddingService {

    @Value("${gcp.project-id}")
    private String projectId;

    @Value("${gcp.location}")
    private String location;

    @Value("${gcp.embedding-model}")
    private String embeddingModel;

    private PredictionServiceClient client;

    @PostConstruct
    public void init() throws IOException {
        PredictionServiceSettings settings = PredictionServiceSettings.newBuilder()
            .setEndpoint(location + "-aiplatform.googleapis.com:443")
            .build();
        client = PredictionServiceClient.create(settings);
    }

    @PreDestroy
    public void destroy() {
        if (client != null) {
            client.close();
        }
    }

    public double[] embed(String text) {
        EndpointName endpoint = EndpointName.ofProjectLocationPublisherModelName(
            projectId, location, "google", embeddingModel);

        Value instance = Value.newBuilder()
            .setStructValue(Struct.newBuilder()
                .putFields("content", Value.newBuilder().setStringValue(text).build())
                .build())
            .build();

        PredictRequest request = PredictRequest.newBuilder()
            .setEndpoint(endpoint.toString())
            .addInstances(instance)
            .build();

        PredictResponse response = client.predict(request);

        ListValue values = response.getPredictions(0)
            .getStructValue()
            .getFieldsOrThrow("embeddings")
            .getStructValue()
            .getFieldsOrThrow("values")
            .getListValue();

        double[] embedding = new double[values.getValuesCount()];
        for (int i = 0; i < values.getValuesCount(); i++) {
            embedding[i] = values.getValues(i).getNumberValue();
        }
        return embedding;
    }
}
