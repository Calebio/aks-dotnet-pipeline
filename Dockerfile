# ---- Stage 1: build ----
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["src/WeatherApi/WeatherApi.csproj", "src/WeatherApi/"]
RUN dotnet restore "src/WeatherApi/WeatherApi.csproj"
COPY . .
WORKDIR "/src/src/WeatherApi"
RUN dotnet publish "WeatherApi.csproj" -c Release -o /app/publish /p:UseAppHost=false

# ---- Stage 2: runtime ----
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
# Create a non-root user and hand it ownership of the app dir
RUN adduser --disabled-password --gecos "" appuser && chown -R appuser /app
USER appuser
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "WeatherApi.dll"]