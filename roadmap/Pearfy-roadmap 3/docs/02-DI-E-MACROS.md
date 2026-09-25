# DI, macros, discovery — contrato técnico

## Objetivo

Permitir ao desenvolvedor escrever `@Service`, `@Repository`, `@RestController` e `@Autowired`, e iniciar a aplicação sem registrar manualmente cada tipo. O equivalente de experiência do Spring Boot é uma inspiração documentada; a implementação deve ser própria e compatível com Swift 6 strict concurrency.

## Princípios de implementação

1. **Constructor injection é a implementação canônica.** `@Autowired` em propriedades é sintaxe de ergonomia: a macro produz uma factory/inicializador e injeta **antes** de expor o objeto. Nunca inserir implicitamente `T!` nem fazer resolve global em cada getter.
2. **Macro local ≠ scanner global.** Macro expande a declaração marcada; um build-tool plugin/manifesto gerado agrega registros por target e por dependências SPM opt-in. Para targets não escaneáveis: registry exportado explícito como fallback documentado.
3. **Tipos e protocolos.** Binding de `any Protocol` é explícito via `@Bind(Protocol.self)` ou `@Bean` tipado. Conformidade em Swift por si só não determina a preferência em DI.
4. **Erros cedo.** Validar bindings, ciclos, ambiguidades, incompatibilidade de escopo, tipos `Sendable` e lifecycle antes de iniciar HTTP, sempre que possível. Erro de expansão em compile time quando local; erro no bootstrap para grafo entre módulos.
5. **Escopo não é thread local.** Request context deve ser explícito ou transportar-se com semântica controlada de tarefas; tarefas destacadas não podem herdar/acessar sessão acidentalmente.
6. **Sem reflexão frágil.** Não depender de `Mirror` para inventariar todas as declarações do projeto.

## Anotações alvo

| Macro | Função | Primeira fase |
|---|---|---|
| `@Component` | Registro genérico | 0.2 |
| `@Service` | Serviço de domínio/aplicação | 0.2 |
| `@Repository` | Infraestrutura de persistência | 0.2 |
| `@RestController` | Controller HTTP | 0.2 |
| `@Autowired` / `@Inject` | Injeção na construção | 0.2 |
| `@Bind` | Expõe protocolo explicitamente | 0.2 |
| `@Qualifier` / `@Primary` | Seleção determinística | 0.2 |
| `@Scope` | singleton, transient e depois request/session | 0.2/0.4 |
| `@Configuration` / `@Bean` | Factory explícita | 0.2 |
| `@Profile` / `@ConditionalOnProperty` | Registro condicional | 0.4 |
| `@Lazy` | Construção adiada com restrições de ciclo | pós-0.2 |

## Semântica de escopos

- `singleton`: uma instância por contexto de aplicação, isolada de outros contextos/testes.
- `transient`: nova instância por resolução.
- `request`: uma instância por request; proibir seu consumo por singleton sem proxy/provider explicitamente tipado.
- `session`: somente após implementação do módulo de sessões; não pressupor memória distribuída.
- Factories async: inicialização/coalescing de singleton concorrente; cancelamentos; deadline; sem deadlock e sem manter NSLock através de `await`.

## Exemplo alvo (ainda não compilável no starter)

```swift
import Pearfy

protocol GreetingRepository: Sendable {
    func greeting() -> String
}

@Repository
@Bind(GreetingRepository.self)
struct DefaultGreetingRepository: GreetingRepository {
    func greeting() -> String { "Hello from Pearfy!" }
}

@Service
final class GreetingService: Sendable {
    @Autowired let repository: any GreetingRepository
    func hello() -> String { repository.greeting() }
}

@RestController("/hello")
final class GreetingController: Sendable {
    @Autowired let service: GreetingService
    @Get func hello() -> String { service.hello() }
}
```

**Atenção:** `final class ...: Sendable` só compila quando todos os stored properties e o modelo de isolamento respeitam as exigências de Swift 6; macros não podem desativar checks por conveniência. Exemplo de contrato, sujeito a refinamento da sintaxe da macro.

## Plano de implementação do discovery

1. Definir estrutura de metadata com symbol, source file, factory symbol, scope, qualifiers e bindings.
2. Macro gera registro **local** para o tipo e diagnósticos por sintaxe.
3. Plugin de build enumera arquivos Swift do target suportado, agrega registros com IDs estáveis; a saída gerada é fonte Swift explícita.
4. Cada target exporta `PearfyModuleRegistration`; o root agrega as registries declaradas/geradas via metadados SPM suportados.
5. Resolver gera grafo determinístico e monta ApplicationContext; nenhuma nova varredura durante request.
6. Registrar controller sem abrir listener até validar todas as rotas, codecs e beans.

**Risco de POC:** SwiftSyntax macros não podem consultar declarações arbitrárias em outros arquivos; source plugin pode exigir convenções e configurações SPM. Provar factibilidade em dois targets antes de prometer zero-config global.

## Estratégia de erro

- `PEARFY_DI_001` missing component
- `PEARFY_DI_002` multiple candidates
- `PEARFY_DI_003` circular dependency (caminho completo)
- `PEARFY_DI_004` scope mismatch
- `PEARFY_DI_005` failed factory com causa encadeada
- `PEARFY_DI_006` lifecycle failure

## Testes obrigatórios

Tipos concretos, `any Protocol`, overrides por qualifier, primary, contexto duplo, singleton sob concorrência, transient, ciclos indiretos, async initialization, cancellation, request scope, erros determinísticos e multi-target package discovery.
