import Foundation
import LLMkit

/// Fork F11: `AnthropicLLMClient.chatCompletion` with `output_config.effort`. LLMkit's client takes
/// no extra fields and its HTTP helpers are internal, so this sends the same request (headers,
/// fields, 8192 max tokens) plus the effort, with the same retries: three attempts; 429 and 5xx after
/// 1 s and 2 s; a timeout again at once when `retryOnTimeout`; the same `LLMKitError`s.
enum AnthropicEffortClient {
    static func chatCompletion(
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String?,
        effort: String,
        maxTokens: Int = 8192,
        timeout: TimeInterval,
        retryOnTimeout: Bool
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.missingAPIKey
        }
        let system = systemPrompt
            ?? messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n").nilIfEmpty
        let body = AnthropicEffortRequestBody(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages.filter { $0.role != "system" }.map { .init(role: $0.role, content: $0.content) },
            effort: effort
        )
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LLMKitError.encodingError
        }

        let (data, response) = try await send(request, timeout: timeout, retryOnTimeout: retryOnTimeout)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMKitError.httpError(
                statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "No error details")
        }
        do {
            return try AnthropicEffortRequestBody.text(fromResponse: data)
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }
    }

    private static func send(
        _ request: URLRequest, timeout: TimeInterval, retryOnTimeout: Bool
    ) async throws -> (Data, URLResponse) {
        let maxRetries = 2
        var lastError: (any Error)?
        var delayBeforeRetry = true
        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            if attempt > 0, delayBeforeRetry {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                    http.statusCode == 429 || (500...599).contains(http.statusCode)
                        || (retryOnTimeout && http.statusCode == 408),
                    attempt < maxRetries
                {
                    delayBeforeRetry = http.statusCode != 408
                    lastError = LLMKitError.httpError(
                        statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
                    continue
                }
                return (data, response)
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                guard retryOnTimeout, attempt < maxRetries else { throw LLMKitError.timeout }
                lastError = LLMKitError.timeout
                delayBeforeRetry = false
            } catch {
                try Task.checkCancellation()
                let nsError = error as NSError
                if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                    throw error
                }
                lastError = error
                delayBeforeRetry = true
            }
        }
        throw lastError ?? LLMKitError.networkError("Request failed after \(maxRetries + 1) attempts")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
