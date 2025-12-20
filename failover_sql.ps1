$clusterListPath = ".\clusters.json"

function Invoke-ClusterFailover {
  param(
    [string]$ClusterName,
    [string]$SqlClusterGroup,
    [string]$TargetNode
  )

  # Ensure the Failover Clustering module is available.
  Import-Module FailoverClusters -ErrorAction Stop

  # Move the SQL Server clustered role to the target node.
  Move-ClusterGroup `
    -Cluster $ClusterName `
    -Name $SqlClusterGroup `
    -Node $TargetNode `
    -Wait 120 `
    -ErrorAction Stop
}

function Main {
  # Load cluster info from JSON with properties: ClusterName, SqlClusterGroup, TargetNode
  $clusters = Get-Content -Path $clusterListPath | ConvertFrom-Json

  foreach ($cluster in $clusters) {
    try {
      Invoke-ClusterFailover `
        -ClusterName $cluster.ClusterName `
        -SqlClusterGroup $cluster.SqlClusterGroup `
        -TargetNode $cluster.TargetNode
    }
    catch {
      Write-Warning "Failover failed for $($cluster.ClusterName). $($_.Exception.Message)"
    }
  }
}

Main
