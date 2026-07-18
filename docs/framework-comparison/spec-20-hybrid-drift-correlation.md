# SPEC-20 — Correlação híbrida (Jaccard + escalada semântica pontual) no `ship:analyze`

**Eixo:** assertividade + qualidade de sinal
**Fonte da ideia:** auditoria interna (E2E live do pipeline com fixture "calculator" — ver
`scripts/e2e-smoke.sh`).

## Contexto

`analyze-correlate.sh` correlaciona REQ/AC/SC contra código e testes via Jaccard bag-of-words
sobre o **arquivo inteiro** do diff. Duas rodadas de E2E real (build → test → quality →
homolog) reproduziram o mesmo padrão: `analyze` deu FAIL (3 high/11 low) num projeto
objetivamente correto (8/8 AC satisfeitos, 100% dos testes passando, review limpo).

Causa raiz identificada por leitura direta do script: (1) correlacionar por arquivo inteiro
dilui a interseção quando múltiplos requisitos dividem o mesmo arquivo pequeno — comum em
tarefas issue-a-issue focadas, que é justamente o modo de trabalho mais comum; (2) sem stemming,
"functions" (spec) ≠ "function" (código); (3) palavras-chave de sintaxe (`export`, `return`,
`if`, `new`, `throw`...) nunca casam com prosa de spec mas inflam a união em todo arquivo.

O risco não é só precisão — é **erosão de confiança no gate**. Em ambas as rodadas do E2E, o
orquestrador reagiu ao FAIL verificando manualmente e descartando como "artefato de scoring".
Um gate que o próprio pipeline aprende a ignorar por hábito é pior que não ter gate: cria
sensação de verificação sem verificação real. Ver também SPEC-18 (mesma família de risco —
degradar sinal determinístico por custo).

Fixes imediatos já aplicados nesta sessão (ambos verificados com teste A/B direto nos
artefatos reais da fixture "calculator", suíte de 117 testes intacta):
1. Stopword list expandida com ruído sintático comum (não muda algoritmo nem threshold, só
   remove tokens que nunca deveriam contar).
2. Arquivos sob `ship/changes/`, `ship/audits/`, `.context/` excluídos dos candidatos de
   correlação de REQ — antes, `proposal.md`/`design.md` (o próprio texto do spec, commitado em
   modo Local) competiam como "arquivo implementado" e venciam o código real por similaridade
   de vocabulário tautológica (o REQ foi extraído do proposal.md, então bate mais com ele que
   com o código). Confirmado no caso real: REQ-01 casava com `proposal.md` (conf. 0.025) antes
   do fix; depois, corretamente não casa com nada em vez de dar um falso "quase implementado".

**Causa adicional confirmada, não corrigida agora — é o driver dominante da baixa confiança
residual:** a extração de REQ em `analyze-correlate.sh` (regex `awk` na seção "Spec
extraction") captura só o texto da **linha do heading** (`### REQ-01 — Arithmetic functions`),
descartando as linhas de corpo (`**Behavior:** src/calculator.js exports add(a, b),
subtract(a, b), multiply(a, b)...`) que são exatamente onde os nomes de função que baterim com
o código aparecem. Isso explica por que REQ-01 ficou em confiança 0 mesmo depois dos dois fixes
acima — o texto usado pra correlação é só o título curto e genérico, não o corpo rico do
requisito. Este é o problema estrutural que a spec abaixo precisa resolver — via granularidade
de extração (capturar Context/Behavior/Edge cases, não só o título) e/ou via a escalada
semântica pontual.

## O que fazer

Manter Jaccard como filtro rápido/determinístico/zero-dependência para os casos extremos
(confiança muito alta ou muito baixa não precisam de LLM). Para a **zona cinzenta** — nem 0 nem
confortavelmente acima do threshold, exatamente onde os falsos positivos da fixture calculator
caíram — escalar para uma verificação semântica pontual e limitada: um REQ/AC específico + o
trecho de código/teste relevante (não o diff inteiro, não uma reavaliação completa), decisão
objetiva de match/no-match. Isso formaliza, de forma auditável e consistente, o que o
orquestrador já faz informalmente e fora do gate hoje.

Requisitos de design a resolver antes de implementar:
- Definir a faixa numérica da "zona cinzenta" (provável candidato inicial: >0 e <0.5, mas
  calibrar com mais fixtures antes de fixar).
- Granularidade da correlação: mover de arquivo inteiro para bloco/função relevante resolveria
  boa parte da diluição sem precisar de LLM — avaliar como alternativa ou complemento à
  escalada semântica, não só como pré-requisito dela.
- Extração de REQ deve capturar o corpo (Context/Behavior/Edge cases/Constraints), não só a
  linha do heading — é a causa confirmada de maior impacto na fixture "calculator" (ver acima).
- Compatibilidade com o cache por hash (`jaccard.json`) já existente — a escalada semântica não
  pode invalidar o cache determinístico dos casos extremos.
- Custo/latência da escalada: bounded ao número de itens na zona cinzenta, nunca ao spec
  inteiro.

## Critérios de aceite

- Casos extremos (confiança muito alta/baixa) continuam 100% determinísticos, sem custo de LLM.
- Reprodução da fixture "calculator" (`scripts/e2e-smoke.sh --fixture calculator`) não produz
  mais FAIL espúrio em `analyze` para um projeto com AC/testes objetivamente satisfeitos.
- Escalada semântica é auditável: cada decisão de zona cinzenta fica registrada (o que foi
  verificado, contra o quê, resultado) — não é uma correção silenciosa do score.
- Sem regressão em drift real: validar que a escalada não "resgata" requisitos genuinamente não
  implementados (testar contra uma fixture com gap real, não só a calculadora limpa).

## Cuidado

Não é para virar "LLM decide tudo" — isso joga fora determinismo/custo/reprodutibilidade que
são propriedades boas do design atual (Jaccard já é rápido, grátis, cacheável, zero dependência
de rede). O ganho está em focar semântica só onde o heurístico barato é genuinamente ambíguo,
não em substituí-lo.
