from langchain_ollama import ChatOllama


# Initialize local Ollama model
llm = ChatOllama(
    model="qwen3.5:4b",
    temperature=0,
    reasoning=False
)


def main():
    print("=" * 50)
    print("Local Qwen3.5 4B Streaming Chatbot")
    print("Type 'exit' or 'quit' to stop")
    print("=" * 50)

    while True:
        user_input = input("\nYou: ")

        if user_input.lower() in {"exit", "quit"}:
            print("\nGoodbye!")
            break

        if not user_input.strip():
            continue

        try:
            print("\nQwen: ", end="", flush=True)

            # Stream the response
            for chunk in llm.stream(user_input):
                if chunk.content:
                    print(chunk.content, end="", flush=True)

            print()  # New line after response

        except Exception as e:
            print(f"\nError: {e}")


if __name__ == "__main__":
    main()