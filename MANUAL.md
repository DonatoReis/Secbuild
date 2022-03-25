MANUAL.md
# MANUAL

## Instalação de novas ferramentas

O arquivo package.ini possui seções para cada ferramenta instalada/utilizada pelo GhostRecon.
Para instalação são utilizados 3 atributos, dos quais 1 dos 2 são obrigatórios para efetuar a instalação da ferramenta.

[Nome-da-ferramenta]							→ Nome genérico da ferramenta para identificação e chamada no código
url='https://github.com/user/repositório'		→ Url para instalação da ferramenta. Git clone, pip -r requirements, python setup.py 													são executados.
script='script.py'								→ Nome do script que deve ser chamado na execução da ferramenta, será criado um link 													simbólico deste script em /usr/local/bin
post_install='comando1; comando2; comandoN;'	→ Comandos executados pós instalação

url ou post_install são obrigatórios na instalação da ferramenta [Ferramenta]

Para incluir novas ferramentas é aconselhável fazer a instalação manual desta ferramenta seguindo o manual de instalação fornecido pela própria ferramenta. Após a instalação manual com sucesso, deve-se anotar os passos executados e para comandos como git clone, pip -r requirements.txt e python setup.py, é necessário apenas incluir a `url` na seção da ferramenta. Para outros comandos necessários à instalação da ferramenta, esses comandos devem ser incluídos em `post_install` na seção da ferramenta.
Incluída uma nova seção no arquivo package.ini, pode-se realizar um teste executando no diretório do GhostRecon `sudo ./install.sh nova-ferramenta` como aparece na definição da seção da ferramenta entre colchetes `[nova-ferramenta]`


## Execução de novas ferramentas

No arquivo package.ini a mesma seção de ferramentas também recebe atributos para execução das ferramentas

[Nome-da-ferramenta]
command='comando-da-ferramenta -p param1 -n paramN'			→ Comandos de execução da ferramenta
depends='comando1 comando2 comandoN'						→ Dependências da ferramenta
description='Descrição que aparecerá no menu de seleção'	→ Descrição no menu de seleção

alguns padrões ficam disponíveis na execução de command como
$domain			→ Domínio alvo do recon
$logfile		→ Resultado de saída da ferramenta, será incluído no relatório e segue o padrão "$logdir/${dtreport}nome-da-ferramenta.log"
$logdir			→ Diretório de logs e saída da ferramenta
$dtreport		→ Datetime de execução da ferramenta (padrão: %Y%m%d%H%M%S)

