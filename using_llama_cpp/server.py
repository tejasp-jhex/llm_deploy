import os
from fastapi import FastAPI, Depends, HTTPException
from fastapi.security.api_key import APIKeyHeader
from fastapi.middleware.cors import CORSMiddleware
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langserve import add_routes
from starlette.requests import Request

# Define key settings
API_KEY_SECRET = "your-super-secure-custom-api-key-here"

async def validate_api_key(request: Request):
    """Dynamic check that catches both lowercase and title-case API key headers."""
    # Read directly from request headers to bypass case enforcement limitations
    api_key = request.headers.get("x-api-key") or request.headers.get("X-API-Key")
    
    if not api_key or api_key != API_KEY_SECRET:
        print('API KEY didn\'t matched ',api_key, API_KEY_SECRET)
        raise HTTPException(
            status_code=403, 
            detail="Invalid or missing API Key. Access Denied."
        )
    return api_key

app = FastAPI(title="Secure LangServe Gateway")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Public Health Check Route ---
@app.get("/health", tags=["Health"])
async def health_check():
    """Simple public health check endpoint to verify service availability."""
    return {"status": "healthy"}

llm = ChatOpenAI(
    base_url="http://localhost:8080/v1",
    api_key="not-needed",
    model="local-model",
    temperature=0,
    max_tokens=500,
    model_kwargs={
        "extra_body": {
            "reasoning": False,
            "cache_prompt": True,
            "slot_id": 0
        }
    }
)

prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a helpful AI assistant. Do not show or generate reasoning/thinking. Return only the final answer."),
    MessagesPlaceholder(variable_name="messages")
])

chain = prompt | llm

# Explicit dependency integration ensures LangServe handles security validations 
# properly across all child endpoints (/chat/stream, /chat/invoke, etc.)
add_routes(
    app,
    chain,
    path="/chat",
    dependencies=[Depends(validate_api_key)],
    enable_feedback_endpoint=False
)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
