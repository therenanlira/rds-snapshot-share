# RDS Snapshots Share - Script de Compartilhamento Cross-Account/Cross-Region

Este script automatiza o processo de compartilhamento e migração de clusters Aurora PostgreSQL entre contas e regiões AWS.

## 🎯 **Funcionalidades**

- ✅ **Compartilhamento Cross-Account**: Automático com gerenciamento KMS
- ✅ **Migração Cross-Region**: Flexível entre qualquer região AWS
- ✅ **Restauração Automática**: Clusters prontos para uso
- ✅ **Timeouts Otimizados**: Suporta clusters de qualquer tamanho
- ✅ **Limpeza Inteligente**: Remove snapshots temporários
- ✅ **Monitoramento**: Progresso em tempo real
- ✅ **Configuração Flexível**: Adapta-se a diferentes ambientes

## 🚀 **Início Rápido**

### 1. Configurar Variáveis (OBRIGATÓRIO)
Edite o script `rds-snapshots-share.sh` e configure no início:

```bash
# Lista de clusters a migrar
RDS=("cluster-1" "cluster-2" "cluster-3")

# Configurações da conta ORIGEM
FROM_ACCOUNT_PROFILE="meu-perfil-origem"
FROM_ACCOUNT_ID="123456789012"
FROM_REGION="us-east-1"

# Configurações da conta DESTINO
TO_ACCOUNT_PROFILE="meu-perfil-destino"
TO_ACCOUNT_ID="210987654321"
TO_REGION="us-east-2"
TO_SG_ID="sg-xxxxxxxxx"
DB_SUBNET_GROUP="meu-subnet-group"

# Senha para os clusters restaurados
MASTER_PASSWORD="MinhaSenh@Segura123!"
```

### 2. Executar o Script
```bash
./rds-snapshots-share.sh
```

## ⚙️ **Configuração Detalhada**

### Variáveis Obrigatórias

| Variável | Exemplo | Descrição |
|----------|---------|-----------|
| `RDS` | `("cluster-1" "cluster-2")` | Array com nomes dos clusters a migrar |
| `FROM_ACCOUNT_PROFILE` | `"prod-account"` | Perfil AWS da conta origem |
| `FROM_ACCOUNT_ID` | `"123456789012"` | ID da conta AWS origem |
| `FROM_REGION` | `"us-east-1"` | Região AWS origem |
| `TO_ACCOUNT_PROFILE` | `"dev-account"` | Perfil AWS da conta destino |
| `TO_ACCOUNT_ID` | `"210987654321"` | ID da conta AWS destino |
| `TO_REGION` | `"us-east-2"` | Região AWS destino |
| `TO_SG_ID` | `"sg-06cba34a9244380b7"` | Security Group na conta destino |
| `DB_SUBNET_GROUP` | `"private-subnet-group"` | DB Subnet Group na conta destino |
| `MASTER_PASSWORD` | `"MinhaSenh@123!"` | Senha para clusters restaurados |

### Como Encontrar os Valores

#### 1. **IDs das Contas AWS**
```bash
# Para descobrir o ID da conta atual
aws sts get-caller-identity --profile SEU_PERFIL --query Account --output text
```

#### 2. **Security Groups Disponíveis**
```bash
# Listar security groups na conta destino
aws ec2 describe-security-groups \
    --profile SEU_PERFIL_DESTINO \
    --region REGIAO_DESTINO \
    --query 'SecurityGroups[].{ID:GroupId,Name:GroupName,VPC:VpcId}' \
    --output table
```

#### 3. **DB Subnet Groups Disponíveis**
```bash
# Listar subnet groups na conta destino
aws rds describe-db-subnet-groups \
    --profile SEU_PERFIL_DESTINO \
    --region REGIAO_DESTINO \
    --query 'DBSubnetGroups[].{Name:DBSubnetGroupName,VPC:VpcId,Subnets:Subnets[0].SubnetIdentifier}' \
    --output table
```

#### 4. **Clusters RDS Disponíveis**
```bash
# Listar clusters na conta origem
aws rds describe-db-clusters \
    --profile SEU_PERFIL_ORIGEM \
    --region REGIAO_ORIGEM \
    --query 'DBClusters[].{Cluster:DBClusterIdentifier,Engine:Engine,Status:Status}' \
    --output table
```

## 📋 **Pré-requisitos**

### 1. **AWS CLI Configurado**

```bash
# Instalar AWS CLI (se necessário)
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /

# Verificar instalação
aws --version
```

### 2. **Perfis AWS Configurados**

Configure perfis para ambas as contas:

```bash
# Configurar perfil da conta origem
aws configure --profile NOME_PERFIL_ORIGEM
# AWS Access Key ID [None]: AKIA...
# AWS Secret Access Key [None]: xxxxxx
# Default region name [None]: us-east-1
# Default output format [None]: json

# Configurar perfil da conta destino
aws configure --profile NOME_PERFIL_DESTINO
# AWS Access Key ID [None]: AKIA...
# AWS Secret Access Key [None]: xxxxxx
# Default region name [None]: us-east-2
# Default output format [None]: json
```

### 3. **Permissões IAM Necessárias**

#### Conta Origem (Source)
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:CreateDBClusterSnapshot",
                "rds:DescribeDBClusters",
                "rds:DescribeDBClusterSnapshots",
                "rds:ModifyDBClusterSnapshotAttribute",
                "rds:CopyDBClusterSnapshot"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "kms:GetKeyPolicy",
                "kms:PutKeyPolicy",
                "kms:Decrypt",
                "kms:CreateGrant",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        }
    ]
}
```

#### Conta Destino (Target)
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:RestoreDBClusterFromSnapshot",
                "rds:CreateDBInstance",
                "rds:DescribeDBClusters",
                "rds:DescribeDBClusterSnapshots",
                "rds:DescribeDBSubnetGroups",
                "ec2:DescribeSecurityGroups"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "kms:Decrypt",
                "kms:CreateGrant",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        }
    ]
}
```

### 4. **Recursos na Conta Destino**

Antes de executar o script, certifique-se que existem:

- **VPC configurada** com subnets privadas
- **DB Subnet Group** criado e associado às subnets
- **Security Group** com regras adequadas para RDS
- **KMS Key** (opcional, pode usar a default)

### 5. **Validação Rápida**

```bash
# Testar conectividade com ambas as contas
aws sts get-caller-identity --profile SEU_PERFIL_ORIGEM
aws sts get-caller-identity --profile SEU_PERFIL_DESTINO

# Verificar acesso aos clusters origem
aws rds describe-db-clusters --profile SEU_PERFIL_ORIGEM --region REGIAO_ORIGEM

# Verificar recursos na conta destino
aws rds describe-db-subnet-groups --profile SEU_PERFIL_DESTINO --region REGIAO_DESTINO
aws ec2 describe-security-groups --profile SEU_PERFIL_DESTINO --region REGIAO_DESTINO
```

## ⏱️ **Tempo de Execução**

| Tamanho do Cluster | Tempo Estimado |
|-------------------|----------------|
| < 50GB | 30-60 minutos |
| 50-200GB | 1-3 horas |
| > 200GB | 3-6 horas |

## 🔐 **Segurança**

### Gerenciamento KMS Automático
- Configura temporariamente permissões cross-account
- Faz backup da política original
- Restaura automaticamente ao final
- Limpeza garantida mesmo em caso de falha

### Credenciais
- Usa perfis AWS configurados
- Não armazena credenciais no código
- Suporta SSO e chaves tradicionais

## 🔍 **Monitoramento**

### Durante a Execução
- Progress feedback a cada 2-5 minutos
- Estimativas de tempo baseadas no tamanho do cluster
- Status detalhado de cada operação

### Console AWS
- **RDS > Snapshots**: Acompanhar criação e cópia
- **CloudTrail**: Auditoria de todas as ações
- **KMS**: Verificar uso de chaves

## 🛠️ **Estrutura do Projeto**

```
📁 rds-snapshot-share/
├── 📄 rds-snapshots-share.sh          # Script principal
├── 📄 README.md                       # Esta documentação
└── 📄 output.json                     # Saída de comandos AWS (gerado)
```

## 💡 **Exemplo Prático de Configuração**

### Cenário: Migrar do Produção para Sandbox

```bash
# No início do script rds-snapshots-share.sh
RDS=("prod-user-db" "prod-billing-db" "prod-analytics-db")

FROM_ACCOUNT_PROFILE="production-aws"
FROM_ACCOUNT_ID="111111111111"
FROM_REGION="us-east-1"

TO_ACCOUNT_PROFILE="sandbox-aws"
TO_ACCOUNT_ID="222222222222"
TO_REGION="us-west-2"
TO_SG_ID="sg-0a1b2c3d4e5f6g7h8"
DB_SUBNET_GROUP="sandbox-private-subnets"

MASTER_PASSWORD="SandboxDB@2025!"
```

### Passos Detalhados

1. **Descobrir recursos na conta destino:**
```bash
# Security Groups disponíveis
aws ec2 describe-security-groups \
    --profile sandbox-aws \
    --region us-west-2 \
    --query 'SecurityGroups[?contains(GroupName, `rds`) || contains(GroupName, `database`)].{ID:GroupId,Name:GroupName}' \
    --output table

# Subnet Groups disponíveis
aws rds describe-db-subnet-groups \
    --profile sandbox-aws \
    --region us-west-2 \
    --output table
```

2. **Configurar o script e executar:**
```bash
# Editar o script com os valores descobertos
nano rds-snapshots-share.sh

# Executar
chmod +x rds-snapshots-share.sh
./rds-snapshots-share.sh
```

## 🔧 **Solução de Problemas**

### Erro: "Profile not found"
```bash
# Configurar perfis AWS
aws configure --profile production-aws
aws configure --profile sandbox-aws

# Testar conectividade
aws sts get-caller-identity --profile production-aws
aws sts get-caller-identity --profile sandbox-aws
```

### Erro: "Access Denied" em KMS

**Causa:** Conta destino não tem permissão para usar a chave KMS da origem.

**Solução:** O script configura automaticamente, mas se falhar:

```bash
# Verificar chave KMS do cluster origem
aws rds describe-db-clusters \
    --db-cluster-identifier SEU_CLUSTER \
    --profile production-aws \
    --region us-east-1 \
    --query 'DBClusters[0].KmsKeyId'

# Verificar política da chave
aws kms get-key-policy \
    --key-id ARN_DA_CHAVE \
    --policy-name default \
    --profile production-aws \
    --region us-east-1
```

### Erro: "DBSubnetGroupNotFound"

**Causa:** DB Subnet Group não existe na conta destino.

**Solução:**
```bash
# Criar DB Subnet Group
aws rds create-db-subnet-group \
    --db-subnet-group-name "meu-subnet-group" \
    --db-subnet-group-description "Private subnets for RDS" \
    --subnet-ids subnet-xxxxx subnet-yyyyy \
    --profile sandbox-aws \
    --region us-west-2
```

### Erro: "InvalidVPCNetworkStateFault"

**Causa:** Security Group não existe ou está em VPC diferente.

**Solução:**
```bash
# Verificar VPC do DB Subnet Group
aws rds describe-db-subnet-groups \
    --db-subnet-group-name SEU_SUBNET_GROUP \
    --profile sandbox-aws \
    --region us-west-2 \
    --query 'DBSubnetGroups[0].VpcId'

# Listar Security Groups na mesma VPC
aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=vpc-xxxxx" \
    --profile sandbox-aws \
    --region us-west-2 \
    --output table
```

### Timeout em Clusters Grandes

**Para clusters > 100GB:**
- Execute em horários de menor tráfego
- O script usa timeouts otimizados (até 90 minutos)
- Monitore via Console AWS: RDS > Snapshots

### Script Interrompido

**Se o script for interrompido:**

1. **Verificar recursos criados:**
```bash
# Snapshots temporários na origem
aws rds describe-db-cluster-snapshots \
    --profile production-aws \
    --region us-east-1 \
    --query 'DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, `manual`) || contains(DBClusterSnapshotIdentifier, `copy`)].{ID:DBClusterSnapshotIdentifier,Status:Status}'

# Snapshots na conta destino
aws rds describe-db-cluster-snapshots \
    --profile sandbox-aws \
    --region us-west-2 \
    --query 'DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, `cross-account`)].{ID:DBClusterSnapshotIdentifier,Status:Status}'
```

2. **Limpeza manual (se necessário):**
```bash
# Deletar snapshots temporários
aws rds delete-db-cluster-snapshot \
    --db-cluster-snapshot-identifier SNAPSHOT_ID \
    --profile PROFILE \
    --region REGIAO
```

### Verificar Status de Migração

```bash
# Clusters criados na conta destino
aws rds describe-db-clusters \
    --profile sandbox-aws \
    --region us-west-2 \
    --query 'DBClusters[?contains(DBClusterIdentifier, `sandbox`)].{Cluster:DBClusterIdentifier,Status:Status,Engine:Engine}' \
    --output table
```

## � **Considerações de Custos**

### Custos Envolvidos

| Item | Estimativa | Observações |
|------|------------|-------------|
| **Snapshots** | $0.095/GB/mês | Armazenamento em ambas as contas |
| **Transferência Cross-Region** | $0.02/GB | Uma única vez durante a cópia |
| **Instâncias RDS** | Preço normal | Clusters restaurados na conta destino |
| **KMS** | $1/mês por chave | Se usar chaves customizadas |

### Otimização de Custos

```bash
# Após migração, deletar snapshots temporários
aws rds describe-db-cluster-snapshots \
    --profile sandbox-aws \
    --region us-west-2 \
    --query 'DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, `cross-account`)].DBClusterSnapshotIdentifier' \
    --output text | while read snapshot; do
    echo "Deletando: $snapshot"
    aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "$snapshot" \
        --profile sandbox-aws --region us-west-2
done
```

## � **Checklist Pré-Execução**

- [ ] **AWS CLI** instalado e funcionando
- [ ] **Perfis AWS** configurados para ambas as contas
- [ ] **Permissões IAM** validadas (origem e destino)
- [ ] **Security Group** existe na conta destino
- [ ] **DB Subnet Group** existe na conta destino
- [ ] **Variáveis** configuradas no script
- [ ] **Backup** dos dados importantes
- [ ] **Janela de manutenção** agendada (para clusters grandes)

## 🚨 **Importante - Antes de Executar**

⚠️ **LEIA ANTES DE EXECUTAR:**

1. **Teste primeiro** com um cluster pequeno
2. **Monitore custos** de transferência entre regiões
3. **Valide conectividade** entre contas
4. **Tenha backups** dos dados importantes
5. **Execute em horário de menor tráfego** para clusters grandes
6. **Monitore o progresso** via Console AWS
7. **Documentar** as configurações utilizadas

## 📞 **Suporte e Próximos Passos**

### Após Execução Bem-Sucedida

1. **Verificar clusters criados:**
```bash
aws rds describe-db-clusters \
    --profile SEU_PERFIL_DESTINO \
    --region REGIAO_DESTINO \
    --output table
```

2. **Configurar conexões de aplicação**
3. **Atualizar strings de conexão** nos apps
4. **Testar funcionalidade** completa
5. **Monitorar performance** dos novos clusters
6. **Deletar recursos temporários** (snapshots intermediários)

### Em Caso de Problemas

1. **Verificar logs** do script
2. **Consultar CloudTrail** para auditoria
3. **Verificar permissões** IAM
4. **Testar conectividade** AWS CLI
5. **Verificar cotas** da conta AWS

### Automação Futura

Para execuções regulares, considere:
- Usar **AWS Lambda** + **Step Functions**
- Implementar **SNS notifications**
- Criar **CloudWatch dashboards**
- Usar **Parameter Store** para configurações

---

**✅ Script pronto para uso independente!**

*Todas as informações necessárias estão documentadas neste README.*
