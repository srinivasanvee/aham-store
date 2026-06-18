package com.ahamstore.api.model;

import lombok.Builder;
import lombok.Data;

import java.util.List;

@Data
@Builder
public class QueryResponse {
    private String answer;
    private List<String> sources;
}
