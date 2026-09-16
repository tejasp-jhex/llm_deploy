import asyncio
from langchain_core.messages import HumanMessage
from langserve import RemoteRunnable

async def main():
    # FIX: Pass the authentication headers directly inside the RemoteRunnable constructor!
    # This guarantees that the header is persistently attached to ALL backend network requests
    # including invoke, batch, and streaming event loops.
    remote_chain = RemoteRunnable(
        "http://localhost:8000/chat",
        headers={
            "x-api-key": "your-super-secure-custom-api-key-here"
        }
    )
    
    messages = [HumanMessage(content="Hello! Introduce yourself briefly.")]
    
    print("Assistant: ", end="", flush=True)
    
    # Clean execution call without splitting headers down into structural configurations
    async for chunk in remote_chain.astream({"messages": messages}):
        print(chunk.content, end="", flush=True)
    print()

if __name__ == "__main__":
    asyncio.run(main())
