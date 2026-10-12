export function backgroundFailure(phase, error) {
    const rawCode = error instanceof Error && "code" in error ? error.code : undefined;
    const code = typeof rawCode === "string" && /^[A-Za-z0-9_.-]{1,64}$/.test(rawCode) ? rawCode : undefined;
    console.error({
        timestamp: new Date().toISOString(),
        context: {
            phase
        },
        error: error instanceof Error ? error.name : "Background operation failed",
        ...code ? {
            code
        } : {}
    });
}
export function providerFailure(phase, error) {
    const detail = error && typeof error === "object" ? error : {};
    console.error({
        timestamp: new Date().toISOString(),
        context: {
            phase,
            ...typeof detail.status === "number" ? {
                status: detail.status
            } : {},
            ...typeof detail.requestId === "string" ? {
                requestId: detail.requestId
            } : {}
        },
        error: error instanceof Error ? error.name : "Provider request failed"
    });
}
