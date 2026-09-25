# Paridade funcional pretendida — Spring Boot → Pearfy

Esta **é a única seção de referência comparativa de nomes**, junto com textos explicativos de outros `.md`. Não inserir `Spring Boot` nem identificadores de marca derivados em `.swift`, `.sh`, manifests, nomes de pastas, comentários de código ou outras extensões. Pearfy é uma implementação própria em Swift, não um port literal.

| Spring / Spring Boot | Pearfy planejado | Prioridade |
|---|---|---|
| Spring Context / Beans | PearfyContext / PearfyDI | P0 |
| `@Component`, `@Service`, `@Repository`, `@Autowired` | Macros de mesma ergonomia, código gerado nativo | P0 |
| Spring Boot autoconfiguration / starters | PearfyDiscovery / starters opt-in | P0 |
| Spring Web MVC | PearfyWeb / PearfyNIO | P0 |
| Spring Configuration Properties / Profiles | PearfyConfiguration | P0 |
| Spring Validation | PearfyValidation | P0 |
| Spring Data JDBC/JPA | PearfyData e drivers; SQL primeiro, ORM opcional depois | P0 |
| Spring Transactions | `@Transactional` e transaction context async | P0 |
| Spring Security | PearfySecurity | P0 produção |
| Spring Boot Actuator | PearfyActuator | P0 produção |
| Spring Boot Test | PearfyTesting | P0 transversal |
| Spring Cache | PearfyCache | P1 |
| Spring AMQP / Kafka | PearfyMessaging / adapters | P1 |
| Spring Scheduling / Spring Batch | PearfyJobs / PearfyBatch | P1 |
| Spring Cloud / OpenFeign | PearfyCloud / HTTP client declarativo | P2 |
| Spring AI | PearfyAI | P2 |

**Não significam paridade plena:** os módulos Pearfy têm critérios próprios; recursos mais sofisticados como ORM, Batch e OAuth2/OIDC exigem escopos e auditoria independentes. Uma anotação com nome semelhante não garante comportamento idêntico. A API documentada é alvo de projeto.
