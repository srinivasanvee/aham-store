package com.ahamstore.api.model;

import java.util.List;

public class QueryResponse {
    private final String answer;
    private final List<String> sources;

    private QueryResponse(Builder builder) {
        this.answer = builder.answer;
        this.sources = builder.sources;
    }

    public String getAnswer() { return answer; }
    public List<String> getSources() { return sources; }

    public static Builder builder() { return new Builder(); }

    public static class Builder {
        private String answer;
        private List<String> sources;

        public Builder answer(String answer) { this.answer = answer; return this; }
        public Builder sources(List<String> sources) { this.sources = sources; return this; }
        public QueryResponse build() { return new QueryResponse(this); }
    }
}
